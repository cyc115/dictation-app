import AVFoundation
import XCTest
@testable import DictationKit

/// A speech engine that hears `text` (or fails with `error`) and, with `utterances`, sends them
/// while "speaking" as the on-device model does for type-as-you-speak.
final class FakeEngine: DictationEngine {
    var isBatch = false
    var archive: RecordingArchive?
    var note: RecordingNote?
    var text = "hello world"
    var error: String?
    var utterances: [String] = []
    private(set) var started = 0
    private(set) var cancelled = 0

    func start(inputUID: String, onLevel: @escaping (Float) -> Void,
               onUtterance: ((String) -> Void)?, onError: @escaping (String) -> Void) {
        started += 1
        utterances.forEach { onUtterance?($0) }
    }

    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        let text = text, error = error
        DispatchQueue.main.async { if let error { failure(error) } else { completion(text) } }
    }

    func cancel() { cancelled += 1 }
}

/// Start → stop → polish → paste through the app's real `DictationController`, with a fake engine,
/// polish and paste, and throwaway History, Insights and recordings.
final class DictationControllerTests: XCTestCase {
    private var settings: AppSettings!
    private var history: HistoryStore!
    private var insights: Insights!
    private var engine: FakeEngine!
    private var pasted: [String] = []
    private var typed: [String] = []
    /// What reached the app, in order: "paste:<text>", "type:<text>", "return".
    private var keys: [String] = []
    private var idle = 0

    /// `realEngines`: the app's own engine choice instead of `engine`.
    private func makeController(realEngines: Bool = false) -> DictationController {
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
        injector.paste = { [unowned self] in
            pasted.append(pasteboard.string(forType: .string) ?? "")
            keys.append("paste:" + (pasted.last ?? ""))
        }
        injector.typeText = { [unowned self] in typed.append($0); keys.append("type:" + $0) }
        injector.postReturn = { [unowned self] in keys.append("return") }
        let overlay = OverlayWindow()
        overlay.makePanel = { OffscreenPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false) }
        addTeardownBlock { overlay.hide() }
        let controller = DictationController(
            settings: settings, overlay: overlay, injector: injector, history: history, insights: insights,
            archive: RecordingArchive(directory: makeTempURL(self, "Recordings")), muter: OutputMuter(defaults: makeDefaults(self)))
        if !realEngines { controller.makeEngine = { [unowned self] _ in engine } }
        controller.sendDelay = 0.01
        controller.onIdle = { [unowned self] in idle += 1 }
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

    func testTypeAsYouSpeakTypesPhrasesThenTheTailWithoutPasting() {
        let controller = makeController()
        settings.streamWhileSpeaking = true
        settings.polishEnabled = true  // not used while streaming
        engine.utterances = ["hello"]
        controller.start()
        XCTAssertEqual(typed, ["hello"])
        controller.stop()
        waitUntil { !controller.isBusy }
        XCTAssertEqual(typed, ["hello", " world"])
        XCTAssertEqual(pasted, [])
        XCTAssertEqual(history.entries.first?.text, "hello world")
        XCTAssertEqual(history.entries.first?.setup, "on-device")
        XCTAssertNotNil(history.entries.first?.transcribeSeconds)
    }

    // MARK: Enter button

    func testEnterWhileIdleJustPressesReturn() {
        let controller = makeController()
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

    func testEnterSendsAfterTypeAsYouSpeak() {
        let controller = makeController()
        settings.streamWhileSpeaking = true
        engine.utterances = ["hello"]
        controller.start()
        controller.enter()
        waitUntil { keys.count == 3 }
        XCTAssertEqual(keys, ["type:hello", "type: world", "return"])
    }

    func testEnterAfterAStopWaitsForTheTextThenSends() {
        let controller = makeController()
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
