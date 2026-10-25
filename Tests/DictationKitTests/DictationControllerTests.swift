import AVFoundation
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

    /// The last dictation's mic events, to send as the mic would, and whether backups were asked for.
    private(set) var onMic: ((MicEvent) -> Void)?
    private(set) var backups: Bool?

    func start(inputUID: String, backups: Bool, onLevel: @escaping (Float) -> Void, onMic: @escaping (MicEvent) -> Void,
               onError: @escaping (String) -> Void) {
        started += 1
        self.onMic = onMic
        self.backups = backups
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

    /// `realEngines`: the app's own engine choice instead of `engine`.
    private func makeController(realEngines: Bool = false, overlay: OverlayWindow = OverlayWindow()) -> DictationController {
        settings = makeSettings(self)
        settings.interactionSounds = false
        history = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        insights = Insights(defaults: makeDefaults(self))
        engine = FakeEngine()
        let pasteboard = makePasteboard(self)
        let injector = TextInjector()
        injector.pasteboard = pasteboard
        injector.restoreDelay = 0.01
        injector.canPaste = { true }
        injector.charBeforeCursor = { nil }
        injector.paste = { [unowned self] in
            pasted.append(pasteboard.string(forType: .string) ?? "")
            keys.append("paste:" + (pasted.last ?? ""))
        }
        injector.postReturn = { [unowned self] in keys.append("return") }
        overlay.makePanel = { OffscreenPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false) }
        addTeardownBlock { overlay.hide() }
        commands = CommandMode(folder: makeTempURL(self, "Commands"), history: history)
        fakeSystem(commands, message: "Volume 40%") { [unowned self] in ran.append($0) }
        commands.makeDecider = { [unowned self] _, _ in FakeDecider(decision: decision, log: decided) }
        let controller = DictationController(
            settings: settings, overlay: overlay, injector: injector, history: history, insights: insights,
            archive: RecordingArchive(directory: makeTempURL(self, "Recordings")), muter: OutputMuter(defaults: makeDefaults(self)),
            commandMode: commands)
        if !realEngines { controller.makeEngine = { [unowned self] _ in engine } }
        controller.activeInput = { _ in FakeMics.wired }  // not this Mac's mics
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

    /// A Bluetooth mic: the pill shows it starting until the mic reports live, and follows a switch.
    func testBluetoothMicShowsTheWaitUntilLive() {
        let controller = makeController()
        controller.activeInput = { _ in FakeMics.buds }
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
        controller.activeInput = { _ in FakeMics.buds }
        settings.microphoneUID = FakeMics.buds.uid
        controller.start()
        XCTAssertEqual(engine.backups, true)
        engine.onMic?(.switched(to: FakeMics.webcam))
        XCTAssertFalse(controller.overlay.isWarmingUp)
        XCTAssertTrue(controller.overlay.micLabel.stringValue.hasSuffix("Logitech BRIO"))
        XCTAssertEqual(settings.microphoneUID, FakeMics.webcam.uid)
        controller.cancel()
    }

    func testIntelligentMicSelectionOff() {
        let controller = makeController()
        settings.intelligentMicSelection = false
        controller.start()
        XCTAssertEqual(engine.backups, false)
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
        controller.activeInput = { _ in FakeMics.wired }
        controller.start()
        XCTAssertFalse(controller.overlay.isWarmingUp)
        XCTAssertTrue(controller.overlay.micLabel.stringValue.hasSuffix("USB Mic"))
        controller.cancel()
    }

    func testMicEventsAfterTheDictationAreIgnored() {
        let controller = makeController()
        controller.activeInput = { _ in FakeMics.buds }
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
        controller.makePolish = { _ in PolishService(backend: FakePolish(delay: 0.1)) }
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
        controller.makePolish = { _ in PolishService(backend: FakePolish(delay: 0.01, log: log)) }
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

    /// Settings → Show detailed analytics shows which model answered each dictation, main or backup.
    func testHistoryKeepsWhichModelsAnswered() {
        let controller = makeController()
        settings.polishEnabled = true
        engine.lastAnswer = ModelAnswer(main: "speech-main", backup: "speech-backup", byBackup: true)
        let main = FakePolish(delay: 2), backup = FakePolish(delay: 0.01)
        main.name = "polish-main"
        backup.name = "polish-backup"
        controller.makePolish = { _ in PolishService(backend: main, backup: backup, backupAfter: 0.05) }
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
        XCTAssertEqual(decided.events, ["decide: 声音小一点 among " + Command.builtIn.map(\.name).joined(separator: ",")])
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
        XCTAssertEqual(decided.events, [])
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
        controller.makePolish = { _ in polished += 1; return PolishService(backend: FakePolish(delay: 0, log: EventLog())) }
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
        controller.makePolish = { _ in PolishService(backend: FakePolish(delay: 0.01, log: EventLog())) }
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
        controller.makePolish = { _ in PolishService(backend: FakePolish(delay: 0.1, log: EventLog())) }
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
}
