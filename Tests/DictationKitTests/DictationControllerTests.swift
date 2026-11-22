import AVFoundation
import Combine
import XCTest
@testable import DictationKit

/// A speech engine that hears `text` (or fails with `error`).
final class FakeEngine: DictationEngine {
    var isBatch = false
    var archive: RecordingArchive?
    var note: RecordingNote?
    var text = "hello world"
    var error: String?
    /// Which model "answered", as CloudEngine reports it.
    var lastAnswer: ModelAnswer?
    var context = SpeechContext.none
    private(set) var started = 0
    private(set) var cancelled = 0

    /// The last dictation's mic events, to send as the mic would, and the mics it was given.
    private(set) var onMic: ((MicEvent) -> Void)?
    private(set) var mics: MicPick?

    func start(mics: MicPick?, onLevel: @escaping (Float) -> Void, onMic: @escaping (MicEvent) -> Void,
               onError: @escaping (String) -> Void) {
        started += 1
        self.onMic = onMic
        self.mics = mics
    }

    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        let text = text, error = error
        DispatchQueue.main.async { if let error { failure(error) } else { completion(text) } }
    }

    func cancel() { cancelled += 1 }
}

/// The pill, logging each mode it moves to (repeats dropped).
final class OverlayLog: OverlayWindow {
    private(set) var shown: [Mode] = []
    private func log() { if shown.last != mode { shown.append(mode) } }
    override func showListening(micName: String? = nil, warmingUp: Bool = false, command: Bool = false) {
        super.showListening(micName: micName, warmingUp: warmingUp, command: command); log()
    }
    override func showProcessing() { super.showProcessing(); log() }
    override func show(_ message: PillMessage) { super.show(message); log() }
    override func hide() { super.hide(); log() }
}

/// Start → stop → polish → paste through the app's real `DictationController`, with a fake engine,
/// polish and paste, and throwaway History, Insights and recordings.
final class DictationControllerTests: XCTestCase {
    private var settings: AppSettings!
    private var history: HistoryStore!
    private var vocabulary: VocabularyStore!
    private var insights: Insights!
    private var engine: FakeEngine!
    private var pasted: [String] = []
    /// What reached the app, in order: "paste:<text>", "return".
    private var keys: [String] = []
    private var idle = 0
    private var commands: CommandMode!
    private var decision = CommandDecision(command: "volume", choice: "-10", confidence: 0.99)
    private let decided = EventLog()
    private var ran: [String] = []
    /// Where you are while dictating (Paste where you dictated).
    private var desk = FakeDesk()
    /// The edit watcher's fake Mac, while a test has one.
    private var editDesk: FakeEditDesk?
    /// The text box each paste asked about the character before the cursor (nil: it had none to ask).
    private var askedFields: [AXUIElement?] = []

    /// `realEngines`: the app's own engine choice instead of `engine`.
    private func makeController(realEngines: Bool = false, overlay: OverlayWindow? = nil) -> DictationController {
        let overlay = overlay ?? makeOverlay(fixedScale: true)
        settings = makeSettings(self)
        settings.interactionSounds = false
        history = makeHistory(self)
        vocabulary = makeVocabulary(self)
        insights = Insights(defaults: makeDefaults(self))
        engine = FakeEngine()
        let pasteboard = makePasteboard(self)
        let injector = TextInjector()
        injector.pasteboard = pasteboard
        injector.restoreDelay = 0.01
        injector.canPaste = { true }
        injector.charBeforeCursor = { [unowned self] field in askedFields.append(field); return nil }
        injector.paste = { [unowned self] in
            pasted.append(pasteboard.string(forType: .string) ?? "")
            keys.append("paste:" + (pasted.last ?? ""))
        }
        injector.postReturn = { [unowned self] in keys.append("return") }
        commands = CommandMode(folder: makeTempURL(self, "Commands"), history: history)
        fakeSystem(commands, message: "Volume 40%") { [unowned self] in ran.append($0) }
        commands.makeDecider = { [unowned self] _, _ in FakeDecider(decision: decision, log: decided) }
        let controller = DictationController(
            settings: settings, overlay: overlay, injector: injector, history: history, insights: insights,
            archive: RecordingArchive(directory: makeTempURL(self, "Recordings")), muter: OutputMuter(defaults: makeDefaults(self)),
            commandMode: commands, vocabulary: vocabulary)
        if !realEngines { controller.makeEngine = { [unowned self] _ in engine } }
        controller.pickMics = { _, _ in MicPick(chosen: FakeMics.wired) }  // not this Mac's mics
        controller.sendDelay = 0.01
        controller.doublePressWindow = 0  // Enter pressed twice in a row runs the command; its own tests set it
        controller.onIdle = { [unowned self] in idle += 1 }
        desk.moveTo(FakeDesk.slack)
        desk.attach(controller.goBack, keys: false)
        return controller
    }

    func testStopPastesWhatWasHeardAndSavesIt() {
        let controller = makeController()
        controller.start()
        XCTAssertTrue(controller.dictating)
        XCTAssertEqual(engine.started, 1)
        controller.stop()
        XCTAssertFalse(controller.dictating)
        XCTAssertTrue(controller.isBusy, "busy until the text is delivered")
        waitUntil { !controller.isBusy }
        XCTAssertEqual(pasted, ["hello world"])
        XCTAssertEqual(history.entries.map(\.text), ["hello world"])
        XCTAssertEqual(history.entries.first?.setup, "on-device")
        XCTAssertEqual(insights.words, 2)
        XCTAssertEqual(idle, 1)
    }

    /// History is written (the whole file) once the text is in front of you, so saving it adds
    /// nothing to your wait.
    func testHistoryIsRecordedAfterThePaste() {
        let controller = makeController()
        let recorded = history.objectWillChange.sink { [unowned self] _ in keys.append("history") }
        defer { recorded.cancel() }
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(keys, ["paste:hello world", "history"])
    }

    /// Each Accessibility question to the front app is a round trip with a 0.1 s limit: where you are is
    /// asked once when you stop and once when the text arrives, and the paste asks that same text box
    /// about the character before the cursor instead of looking it up a third time.
    func testThePasteAsksTheTextBoxItAlreadyFound() {
        let controller = makeController()
        settings.pasteWhereDictated = true
        let where_ = controller.goBack.current
        var lookedUp = 0
        controller.goBack.current = { lookedUp += 1; return where_() }
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(pasted, ["hello world"])
        XCTAssertEqual(lookedUp, 2, "at stop, and when the text arrived")
        XCTAssertEqual(askedFields.count, 1)
        XCTAssertTrue(askedFields.first.flatMap { $0 }.map { CFEqual($0, FakeDesk.slack.field) } ?? false)
    }

    /// The mics are looked up once per start (CoreAudio asks every device several things): the one
    /// the pill names is the one the engine opens, with the backups from the same look-up.
    func testTheEngineOpensTheMicThePillNames() {
        let controller = makeController()
        controller.pickMics = { _, _ in MicPick(chosen: FakeMics.buds, backups: [FakeMics.wired]) }
        controller.start()
        XCTAssertTrue(controller.overlay.isWarmingUp, "the pill shows the Bluetooth mic starting")
        XCTAssertEqual(engine.mics, MicPick(chosen: FakeMics.buds, backups: [FakeMics.wired]))
        controller.cancel()
    }

    /// A Bluetooth mic: the pill shows it starting until the mic reports live, and follows a switch.
    func testBluetoothMicShowsTheWaitUntilLive() {
        let controller = makeController()
        controller.pickMics = { _, _ in MicPick(chosen: FakeMics.buds) }
        controller.start()
        XCTAssertTrue(controller.overlay.isWarmingUp)
        engine.onMic?(.live)
        XCTAssertFalse(controller.overlay.isWarmingUp)
        controller.cancel()
    }

    /// Intelligent mic selection (on by default) moved to a better mic: the pill names it, and it
    /// becomes the Microphone setting for next time.
    func testASwitchNamesTheMicAndBecomesTheSetting() {
        let controller = makeController()
        var askedForBackups: Bool?
        controller.pickMics = { _, backups in askedForBackups = backups; return MicPick(chosen: FakeMics.buds) }
        settings.microphoneUID = FakeMics.buds.uid
        controller.start()
        XCTAssertEqual(askedForBackups, true)
        engine.onMic?(.switched(to: FakeMics.webcam))
        XCTAssertFalse(controller.overlay.isWarmingUp)
        XCTAssertTrue(controller.overlay.micLabel.stringValue.hasSuffix("Logitech BRIO"))
        XCTAssertEqual(settings.microphoneUID, FakeMics.webcam.uid)
        controller.cancel()
    }

    func testIntelligentMicSelectionOff() {
        let controller = makeController()
        settings.intelligentMicSelection = false
        var askedForBackups: Bool?
        controller.pickMics = { _, backups in askedForBackups = backups; return MicPick(chosen: FakeMics.wired) }
        controller.start()
        XCTAssertEqual(askedForBackups, false)
        controller.cancel()
    }

    func testNoAudioGlowsRedUntilAudioComes() {
        let controller = makeController()
        controller.start()
        engine.onMic?(.noAudio)
        XCTAssertTrue(controller.overlay.isShowingNoAudio)
        engine.onMic?(.live)
        XCTAssertFalse(controller.overlay.isShowingNoAudio)
        controller.cancel()
    }

    func testWiredMicStartsReady() {
        let controller = makeController()
        controller.pickMics = { _, _ in MicPick(chosen: FakeMics.wired) }
        controller.start()
        XCTAssertFalse(controller.overlay.isWarmingUp)
        XCTAssertTrue(controller.overlay.micLabel.stringValue.hasSuffix("USB Mic"))
        controller.cancel()
    }

    func testMicEventsAfterTheDictationAreIgnored() {
        let controller = makeController()
        controller.pickMics = { _, _ in MicPick(chosen: FakeMics.buds) }
        controller.start()
        controller.cancel()
        engine.onMic?(.switched(to: FakeMics.builtIn))
        XCTAssertEqual(controller.overlay.mode, .hidden)
        XCTAssertEqual(settings.microphoneUID, "", "a finished dictation's late events change nothing")
    }

    /// Cloud + polish: the pill stays up from stop until the polished text is in. It used to hide
    /// when the transcript arrived and show again for the polish, a visible blink.
    func testCloudPolishKeepsThePillUpUntilTheText() {
        let overlay = OverlayLog()
        let controller = makeController(overlay: overlay)
        engine.isBatch = true
        settings.polishEnabled = true
        controller.makePolish = { _, _ in PolishService(backend: FakePolish(delay: 0.1)) }
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(pasted, ["hello world。"])
        XCTAssertEqual(overlay.shown, [.listening, .processing, .hidden], "no hide and show between transcript and polish")
    }

    func testCloudWithoutPolishHidesWhenTheTextArrives() {
        let overlay = OverlayLog()
        let controller = makeController(overlay: overlay)
        engine.isBatch = true
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(overlay.shown, [.listening, .processing, .hidden])
    }

    func testPolishedTextIsPastedAndTheRawKept() {
        let controller = makeController()
        settings.polishEnabled = true
        let log = EventLog()
        controller.makePolish = { _, _ in PolishService(backend: FakePolish(delay: 0.01, log: log)) }
        controller.start()
        XCTAssertEqual(log.events, ["prepare"], "polish loads while you speak")
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(pasted, ["hello world。"])
        XCTAssertEqual(history.entries.first?.text, "hello world。")
        XCTAssertEqual(history.entries.first?.raw, "hello world")
        XCTAssertNotNil(history.entries.first?.transcribeSeconds)
        XCTAssertGreaterThanOrEqual(history.entries.first?.polishSeconds ?? 0, 0.01, "saved for Insights' time bar")
    }

    func testPolishedTextIsRecordedAfterThePaste() {
        let controller = makeController()
        settings.polishEnabled = true
        controller.makePolish = { _, _ in PolishService(backend: FakePolish(delay: 0.01)) }
        let recorded = history.objectWillChange.sink { [unowned self] _ in keys.append("history") }
        defer { recorded.cancel() }
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(keys, ["paste:hello world。", "history"])
    }

    /// Settings → Show detailed analytics shows which model answered each dictation, main or backup.
    func testHistoryKeepsWhichModelsAnswered() {
        let controller = makeController()
        settings.polishEnabled = true
        engine.lastAnswer = ModelAnswer(main: "speech-main", backup: "speech-backup", byBackup: true)
        let main = FakePolish(delay: 2), backup = FakePolish(delay: 0.01)
        main.name = "polish-main"
        backup.name = "polish-backup"
        controller.makePolish = { _, _ in PolishService(backend: main, backup: backup, backupAfter: 0.05) }
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(history.entries.first?.transcribedBy, ModelAnswer(main: "speech-main", backup: "speech-backup", byBackup: true))
        XCTAssertEqual(history.entries.first?.polishedBy, ModelAnswer(main: "polish-main", backup: "polish-backup", byBackup: true))
    }

    // MARK: Command mode

    func testEnterWhileIdleStartsACommandAndAgainRunsIt() {
        let controller = makeController()
        settings.setOpenRouterKey("test-key")
        engine.text = "声音小一点"
        controller.enter()
        XCTAssertTrue(controller.dictating)
        XCTAssertEqual(controller.kind, .command)
        XCTAssertTrue(controller.overlay.isCommand)
        controller.enter()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(decided.events, ["prepare", "decide: 声音小一点 among " + Command.builtIn.map(\.name).joined(separator: ",")],
                       "readied as recording starts")
        XCTAssertEqual(ran, ["volume -10"])
        XCTAssertEqual(pasted, [], "a command isn't typed")
        XCTAssertEqual(keys, [], "nor sent")
        XCTAssertEqual(history.entries, [], "nor saved as a dictation")
        XCTAssertEqual(insights.words, 0)
        XCTAssertEqual(history.commands.map(\.label), ["volume -10"])
        XCTAssertEqual(controller.overlay.label.stringValue, "Volume 40%")
        XCTAssertEqual(idle, 1)
    }

    func testNotFoundShowsWhatWasHeard() {
        let controller = makeController()
        settings.setOpenRouterKey("test-key")
        engine.text = "open the pod bay doors"
        decision = CommandDecision(command: nil, confidence: 1)
        controller.enter()
        controller.stop()  // the pill's ✓ runs it too
        waitUntil { !controller.isBusy }
        XCTAssertEqual(ran, [])
        XCTAssertEqual(controller.overlay.label.stringValue, "Command not found\n“open the pod bay doors”")
        XCTAssertEqual(history.commands.first?.result, "Command not found")
    }

    func testAFailedCommandSaysWhichAndWhy() {
        let controller = makeController()
        settings.setOpenRouterKey("test-key")
        decision = CommandDecision(command: "brightness", choice: "+10", confidence: 0.97)
        commands.system[Command.brightness.name] = { _, _ in CommandResult(ok: false, message: "No display whose brightness macOS can set") }
        controller.enter()
        controller.enter()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.overlay.label.stringValue, "Brightness didn’t work\nNo display whose brightness macOS can set")
    }

    func testTheDictationButtonDoesNothingDuringACommand() {
        let controller = makeController()
        settings.setOpenRouterKey("test-key")
        controller.enter()
        controller.toggle()
        XCTAssertTrue(controller.dictating, "only the Enter button (or ✓) runs it")
        controller.cancel()
        XCTAssertEqual(decided.events, ["prepare"])
    }

    /// Settings › Experimental › Decide commands on this Mac: command mode works with no key, and
    /// every command goes to the local decider, never Jev (or the commandModel setting's model).
    func testTheLocalDeciderDecidesEveryCommandWithoutAKey() {
        let controller = makeController()
        settings.commandModel = "deepseek/deepseek-v4.1-flash"
        settings.localCommandDecider = true
        var models: [String] = []
        commands.makeDecider = { [unowned self] model, _ in models.append(model); return FakeDecider(decision: decision, log: decided) }
        controller.enter()
        XCTAssertTrue(controller.dictating, "no key needed")
        controller.enter()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(ran, ["volume -10"])
        XCTAssertEqual(models, ["local", "local"], "readied and asked: the local one only")
        settings.localCommandDecider = false
        XCTAssertFalse(settings.commandModeOn, "off again: no key")
    }

    /// Without the API key command mode is off: the Enter button just presses Return, no reminder.
    func testWithoutTheAPIKeyEnterJustPressesReturn() {
        let controller = makeController()
        var missing = 0
        controller.onMissingKey = { _ in missing += 1 }
        controller.enter()
        XCTAssertFalse(controller.dictating)
        XCTAssertEqual(missing, 0)
        XCTAssertEqual(keys, ["return"])
    }

    /// Not polished; with Keep recordings on, its audio is kept apart from the dictations'.
    func testACommandIsNotPolishedAndIsKeptApart() {
        let controller = makeController()
        settings.setOpenRouterKey("test-key")
        settings.polishEnabled = true
        settings.keepRecordings = true
        var polished = 0
        controller.makePolish = { _, _ in polished += 1; return PolishService(backend: FakePolish(delay: 0, log: EventLog())) }
        controller.enter()
        XCTAssertEqual(polished, 0)
        XCTAssertEqual(engine.archive?.directory, controller.archive.directory.appendingPathComponent("Commands"))
        controller.enter()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(ran, ["volume -10"])
        controller.start()
        XCTAssertEqual(engine.archive?.directory, controller.archive.directory, "a dictation's stays where it was")
        controller.cancel()
    }

    /// A command's words go to the speech model; a dictation's context stays empty.
    func testACommandIsToldItsWordsAndADictationIsNot() {
        let controller = makeController()
        settings.setOpenRouterKey("test-key")
        commands.running = { ["Muse"] }
        controller.enter()
        XCTAssertTrue(engine.context.words.contains("press Enter"))
        XCTAssertTrue(engine.context.words.contains("Muse"))
        controller.cancel()
        controller.start()
        XCTAssertEqual(engine.context, .none)
        controller.cancel()
    }

    /// Enter double-clicked: Return, and no command (nor a cancel sound, nor anything in History).
    func testDoubleClickedEnterJustPressesReturn() {
        let controller = makeController()
        settings.setOpenRouterKey("test-key")
        controller.doublePressWindow = 0.35
        controller.enter()
        XCTAssertEqual(controller.kind, .command)
        controller.enter()
        XCTAssertFalse(controller.dictating)
        XCTAssertEqual(engine.cancelled, 1)
        XCTAssertEqual(keys, ["return"])
        spinRunLoop(0.05)
        XCTAssertEqual(ran, [])
        XCTAssertEqual(history.commands, [])
    }

    /// The second press after the double-click time runs the command as before.
    func testEnterAfterTheDoubleClickTimeRunsTheCommand() {
        let controller = makeController()
        settings.setOpenRouterKey("test-key")
        controller.doublePressWindow = 0.05
        controller.enter()
        spinRunLoop(0.1)
        controller.enter()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(ran, ["volume -10"])
        XCTAssertEqual(keys, [])
    }

    /// Right after a dictation stops, the Enter button still sends it: it doesn't start a command.
    func testEnterRightAfterADictationStillSends() {
        let controller = makeController()
        settings.setOpenRouterKey("test-key")
        controller.start()
        controller.stop()
        controller.enter()
        XCTAssertFalse(controller.dictating)
        waitUntil { !controller.isBusy && keys.count == 2 }
        XCTAssertEqual(keys, ["paste:hello world", "return"])
    }

    // MARK: Paste where you dictated

    /// You moved to Notes while the text was on its way: it goes to Slack, is sent, and you're back in Notes.
    func testTextGoesBackToWhereYouDictated() {
        let controller = makeController()
        controller.start()
        controller.enter()
        desk.moveTo(FakeDesk.notes)
        waitUntil { !controller.isBusy }
        XCTAssertEqual(keys, ["paste:hello world", "return"])
        XCTAssertEqual(desk.log, ["block", "front:Slack", "cursor:Slack", "front:Notes", "cursor:Notes", "unblock"])
        XCTAssertEqual(desk.front, 2)
    }

    func testStayingPutPastesWithoutSwitching() {
        let controller = makeController()
        controller.start()
        controller.enter()
        waitUntil { !controller.isBusy && keys.count == 2 }
        XCTAssertEqual(keys, ["paste:hello world", "return"])
        XCTAssertEqual(desk.log, [])
    }

    func testOffPastesWhereYouAre() {
        let controller = makeController()
        settings.pasteWhereDictated = false
        controller.start()
        controller.enter()
        desk.moveTo(FakeDesk.notes)
        waitUntil { !controller.isBusy && keys.count == 2 }
        XCTAssertEqual(desk.log, [])
    }

    /// The box is gone: nothing pasted or sent, and the pill says the text is on the clipboard.
    func testCantGetBackSaysSo() {
        let controller = makeController()
        controller.start()
        controller.enter()
        desk.moveTo(FakeDesk.notes)
        desk.cursor[1] = FakeDesk.box(999)  // Slack's cursor is somewhere else now
        desk.focusWorks = false
        waitUntil { !controller.isBusy }
        XCTAssertEqual(keys, [])
        XCTAssertEqual(controller.overlay.mode, .message)
        XCTAssertEqual(controller.overlay.label.stringValue, "Couldn't get back to Slack: the text is on the clipboard")
    }

    // MARK: Learn from my edits

    /// The edit watcher, on a fake Mac, handed to `controller`, with Learn from my edits on.
    private func watchEdits(_ controller: DictationController) -> (EditWatcher, FakeEditDesk) {
        settings.learnFromEdits = true
        let watcher = EditWatcher(settings: settings, history: history, stats: EditWatchStats(fileURL: makeTempURL(self, "edit-watch.json")))
        let editDesk = FakeEditDesk()
        editDesk.attach(watcher)
        self.editDesk = editDesk  // the watcher's fakes hold it unowned
        controller.editWatcher = watcher
        return (watcher, editDesk)
    }

    /// After a plain paste, with what actually went in and its History entry; the probe finds it.
    func testAPasteIsWatchedAfterItsInHistory() {
        let controller = makeController()
        let (watcher, editDesk) = watchEdits(controller)
        let saved = history.objectWillChange.sink { [unowned self] _ in keys.append(watcher.isWatching ? "history:watching" : "history") }
        defer { saved.cancel() }
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(keys, ["paste:hello world", "history"], "armed after the paste and the save")
        XCTAssertTrue(watcher.isWatching)
        editDesk.show("hello world")
        editDesk.clock.advance(EditWatcher.probeDelay)
        XCTAssertEqual(watcher.stats.apps["Slack"], EditWatchStats.App(armed: 1, probesFailed: 0, gaveUp: 0), "found where the cursor is")
        editDesk.type("x"); editDesk.show("hello there")
        editDesk.press([.returnKey])
        XCTAssertEqual(history.entries[0].capture?.edited, "hello there")
    }

    func testASentDictationIsntWatched() {
        let controller = makeController()
        let (watcher, _) = watchEdits(controller)
        controller.start()
        controller.enter()
        waitUntil { !controller.isBusy && keys.count == 2 }
        XCTAssertFalse(watcher.isWatching)
    }

    func testACommandIsntWatched() {
        let controller = makeController()
        let (watcher, _) = watchEdits(controller)
        controller.start(.command)
        controller.enter()
        waitUntil { !controller.isBusy }
        XCTAssertFalse(watcher.isWatching)
    }

    func testTextTakenBackIsntWatched() {
        let controller = makeController()
        let (watcher, _) = watchEdits(controller)
        controller.start()
        controller.stop()
        desk.moveTo(FakeDesk.notes)
        waitUntil { !controller.isBusy }
        XCTAssertEqual(desk.log.first, "block", "it went through GoBack")
        XCTAssertFalse(watcher.isWatching)
    }

    func testWithHistoryOffNothingIsWatched() {
        let controller = makeController()
        let (watcher, _) = watchEdits(controller)
        history.retention = .off
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertFalse(watcher.isWatching)
    }

    func testANewDictationEndsTheWatch() {
        let controller = makeController()
        let (watcher, _) = watchEdits(controller)
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertTrue(watcher.isWatching)
        controller.start()
        XCTAssertFalse(watcher.isWatching)
        controller.cancel()
    }

    // MARK: Enter button

    func testEnterWhileIdleJustPressesReturnWithCommandModeOff() {
        let controller = makeController()
        settings.commandModeEnabled = false
        controller.enter()
        XCTAssertEqual(keys, ["return"])
        XCTAssertFalse(controller.isBusy)
    }

    func testEnterDuringDictationStopsAndSendsAfterThePaste() {
        let controller = makeController()
        controller.start()
        controller.enter()
        XCTAssertFalse(controller.dictating, "stops like the dictation button")
        XCTAssertEqual(keys, [], "no Return before the text is in")
        waitUntil { keys.count == 2 }
        XCTAssertEqual(keys, ["paste:hello world", "return"])
    }

    func testEnterSendsAfterThePolishedText() {
        let controller = makeController()
        settings.polishEnabled = true
        controller.makePolish = { _, _ in PolishService(backend: FakePolish(delay: 0.01, log: EventLog())) }
        controller.start()
        controller.enter()
        waitUntil { keys.count == 2 }
        XCTAssertEqual(keys, ["paste:hello world。", "return"])
    }

    func testEnterAfterAStopWaitsForTheTextThenSends() {
        let controller = makeController()
        settings.commandModeEnabled = false  // Enter with nothing in progress: a plain Return
        controller.start()
        controller.stop()
        controller.enter()  // text still on the way
        XCTAssertEqual(keys, [], "Return doesn't go out ahead of the text")
        waitUntil { keys.count == 2 }
        XCTAssertEqual(keys, ["paste:hello world", "return"])
        controller.enter()  // text delivered: back to a plain Return
        XCTAssertEqual(keys, ["paste:hello world", "return", "return"])
    }

    func testEnterDuringPolishSendsAfterThePolishedText() {
        let controller = makeController()
        settings.polishEnabled = true
        controller.makePolish = { _, _ in PolishService(backend: FakePolish(delay: 0.1, log: EventLog())) }
        controller.start()
        controller.stop()
        waitUntil { controller.overlay.mode == .processing }
        controller.enter()
        waitUntil { keys.count == 2 }
        XCTAssertEqual(keys, ["paste:hello world。", "return"])
    }

    func testEnterSendsNothingWhenNothingWasHeard() {
        let controller = makeController()
        settings.commandModeEnabled = false  // Enter with nothing in progress: a plain Return
        engine.text = "  "
        controller.start()
        controller.enter()
        waitUntil { !controller.isBusy }
        spinRunLoop(0.05)
        XCTAssertEqual(keys, [])
        controller.enter()
        XCTAssertEqual(keys, ["return"], "afterwards Enter is a plain Return again")
    }

    func testDictationButtonStopDoesNotSend() {
        let controller = makeController()
        controller.start()
        controller.toggle()
        waitUntil { !controller.isBusy }
        spinRunLoop(0.05)
        XCTAssertEqual(keys, ["paste:hello world"])
    }

    func testCancelDeliversNothing() {
        let controller = makeController()
        controller.start()
        controller.cancel()
        XCTAssertEqual(engine.cancelled, 1)
        XCTAssertFalse(controller.isBusy)
        spinRunLoop(0.05)
        XCTAssertEqual(pasted, [])
        XCTAssertEqual(history.entries, [])
        XCTAssertEqual(idle, 1)
    }

    func testFailureShowsTheMessageAndFinishes() {
        let controller = makeController()
        engine.error = "The microphone sent only silence."
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.overlay.mode, .message)
        XCTAssertEqual(controller.overlay.label.stringValue, "The microphone sent only silence.")
        XCTAssertEqual(pasted, [])
        XCTAssertEqual(idle, 1)
    }

    func testCloudModelWithoutKeyAsksForItInsteadOfStarting() {
        let controller = makeController(realEngines: true)
        settings.setup = .cloudFlash  // no key saved in the test settings
        var asked: DictationSetup?
        controller.onMissingKey = { asked = $0 }
        controller.start()
        XCTAssertFalse(controller.dictating)
        XCTAssertEqual(asked, .cloudFlash)
        XCTAssertTrue(controller.overlay.label.stringValue.contains("API key"))
    }

    func testStopsOnItsOwnIfTheStopNeverComes() {
        let controller = makeController()
        controller.autoStopAfter = (0.05, 0.05)
        controller.start()
        waitUntil { !controller.dictating && !controller.isBusy }
        XCTAssertEqual(pasted, ["hello world"])
    }

    // MARK: Vocabulary

    /// Polish that writes down what it was given and answers `answer(input)`.
    private final class EchoPolish: PolishBackend {
        var inputs: [String] = []
        let answer: (String) -> String
        init(_ answer: @escaping (String) -> String = { $0 }) { self.answer = answer }
        func polish(_ text: String) async throws -> String { inputs.append(text); return answer(text) }
    }

    /// Replaced before polish (polish gets the terms) and again after (polish can write a variant back);
    /// History's raw stays what the speech model heard.
    func testVocabularyReplacesBeforeAndAfterPolish() {
        let controller = makeController()
        vocabulary.add(term: "Claude", heardAs: ["cloud"])
        settings.polishEnabled = true
        engine.text = "ask cloud about it"
        let polish = EchoPolish { $0 + ", then cloud." }
        var given: Vocabulary?
        controller.makePolish = { _, vocabulary in given = vocabulary; return PolishService(backend: polish) }
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(polish.inputs, ["ask Claude about it"])
        XCTAssertEqual(given?.entries.map(\.term), ["Claude"], "the polish is built with the vocabulary")
        XCTAssertEqual(pasted, ["ask Claude about it, then Claude."])
        XCTAssertEqual(history.entries.first?.text, "ask Claude about it, then Claude.")
        XCTAssertEqual(history.entries.first?.raw, "ask cloud about it", "what the speech model heard")
        XCTAssertEqual(vocabulary.entries.first?.uses, 2, "both passes count")
    }

    /// With no terms, the polish is asked exactly what it was asked before vocabulary (same input,
    /// same instructions, nothing wrapped) and what it answers is pasted unchanged.
    func testWithNoTermsPolishAndThePasteAreAsBefore() throws {
        let controller = makeController()
        settings.setOpenRouterKey("sk-test")
        vocabulary.add(term: "Off", heardAs: ["of"])
        vocabulary.setEnabled(false, for: vocabulary.entries[0].id)
        let empty = vocabulary.vocabulary(enabled: settings.vocabularyEnabled)
        let service = controller.makePolish(.cloudFlash, empty)
        let main = try XCTUnwrap(service.backend as? OpenRouterPolish)
        let backup = try XCTUnwrap(service.backup as? OpenRouterPolish)
        XCTAssertEqual(main.instructions, DictationSetup.cloudFlash.promptText)
        XCTAssertEqual(backup.instructions, DictationSetup.cloudFlash.promptText)

        settings.polishEnabled = true
        engine.text = "ask cloud of it"
        let polish = EchoPolish { $0 + "。" }
        controller.makePolish = { _, _ in PolishService(backend: polish) }
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(polish.inputs, ["ask cloud of it"])
        XCTAssertEqual(pasted, ["ask cloud of it。"])
        XCTAssertEqual(vocabulary.entries.first?.uses, 0)
    }

    /// Every backend built from the setup is told the terms: main, backup, and on-device.
    func testEveryPolishModelIsToldTheTerms() throws {
        let controller = makeController()
        vocabulary.add(term: "GeForce Now", heardAs: ["G Four Snow"])
        let terms = vocabulary.vocabulary(enabled: true)
        let wanted = terms.instructions(DictationSetup.cloudFlash.promptText)
        XCTAssertTrue(wanted.contains(terms.promptBlock))
        let cloud = controller.makePolish(.cloudFlash, terms)  // no key: on-device, with the cloud setup's prompt
        XCTAssertEqual((cloud.backend as? OnDevicePolish)?.instructions, wanted)
        settings.setOpenRouterKey("sk-test")
        let keyed = controller.makePolish(.cloudFlash, terms)
        XCTAssertEqual((keyed.backend as? OpenRouterPolish)?.instructions, wanted)
        XCTAssertEqual((keyed.backup as? OpenRouterPolish)?.instructions, wanted)
        XCTAssertEqual((controller.makePolish(.onDevice, terms).backend as? OnDevicePolish)?.instructions,
                       terms.instructions(DictationSetup.onDevice.promptText))
    }

    /// The first replacement is before polish, so a polish that fails, comes back empty or runs out
    /// of time still pastes the terms.
    func testAFailedEmptyOrLatePolishStillPastesTheTerms() {
        let controller = makeController()
        vocabulary.add(term: "Claude", heardAs: ["cloud"])
        settings.polishEnabled = true
        engine.text = "ask cloud"
        for service in [PolishService(backend: FakePolish(error: .failed("down"))),
                        PolishService(backend: FakePolish(output: "  ")),
                        PolishService(backend: FakePolish(delay: 2), deadline: 0.05)] {
            controller.makePolish = { _, _ in service }
            controller.start()
            controller.stop()
            waitUntil { !controller.isBusy }
        }
        XCTAssertEqual(pasted, ["ask Claude", "ask Claude", "ask Claude"])
    }

    func testWithPolishOffTheTermsAreReplacedAndTheRawKept() {
        let controller = makeController()
        vocabulary.add(term: "Claude", heardAs: ["cloud"])
        engine.text = "ask cloud"
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(pasted, ["ask Claude"])
        XCTAssertEqual(history.entries.first?.text, "ask Claude")
        XCTAssertEqual(history.entries.first?.raw, "ask cloud")
        XCTAssertNil(history.entries.first?.prompt, "not polished")
    }

    /// Uses are saved once the text is in front of you, after History: nothing added to the wait.
    func testUsesAreSavedAfterThePaste() {
        let controller = makeController()
        vocabulary.add(term: "Claude", heardAs: ["cloud"])
        engine.text = "ask cloud"
        let recorded = [history.objectWillChange.sink { [unowned self] _ in keys.append("history") },
                        vocabulary.objectWillChange.sink { [unowned self] _ in keys.append("uses") }]
        defer { recorded.forEach { $0.cancel() } }
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(keys, ["paste:ask Claude", "history", "uses"])
        XCTAssertEqual(vocabulary.entries.first?.uses, 1)
    }

    func testUseVocabularyOffChangesNothing() {
        let controller = makeController()
        vocabulary.add(term: "Claude", heardAs: ["cloud"])
        settings.vocabularyEnabled = false
        engine.text = "ask cloud"
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(pasted, ["ask cloud"])
        XCTAssertEqual(vocabulary.entries.first?.uses, 0)
    }

    /// `DictationApp vocabulary add` while the app runs: the next dictation has it.
    func testATermAddedFromTheCommandLineIsUsedNextDictation() {
        let controller = makeController()
        VocabularyStore(fileURL: vocabulary.fileURL).add(term: "Claude", heardAs: ["cloud"])
        engine.text = "ask cloud"
        controller.start()
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(pasted, ["ask Claude"])
    }

    /// A command's transcript isn't replaced: only dictations are.
    func testACommandIsNotReplaced() {
        let controller = makeController()
        settings.setOpenRouterKey("test-key")
        vocabulary.add(term: "Claude", heardAs: ["volume"])
        engine.text = "volume down"
        controller.enter()
        controller.enter()
        waitUntil { !controller.isBusy }
        XCTAssertTrue(decided.events.contains { $0.hasPrefix("decide: volume down") }, "\(decided.events)")
        XCTAssertEqual(vocabulary.entries.first?.uses, 0)
    }

    /// The speech hint: off by default; on, plain dictation on an on-device engine gets the terms.
    func testTheSpeechHintGivesOnDeviceModelsTheTerms() {
        let controller = makeController()
        vocabulary.add(term: "Claude", heardAs: ["cloud"])
        controller.start()
        XCTAssertEqual(engine.context, .none, "off by default")
        controller.cancel()
        settings.vocabularySpeechHint = true
        controller.start()
        XCTAssertEqual(engine.context.words, ["Claude"])
        controller.cancel()
        settings.setup = .cloudFlash
        controller.start()
        XCTAssertEqual(engine.context, .none, "the cloud models can't take it")
        controller.cancel()
    }
}
