import AppKit
import XCTest
@testable import DictationKit

/// A pretend Mac for `GoBack`: which app is in front, which box has the cursor in each, and a log
/// of everything done to it, in order.
final class FakeDesk {
    /// Text boxes; any distinct accessibility elements will do (none of them is asked anything).
    static func box(_ id: pid_t) -> AXUIElement { AXUIElementCreateApplication(id) }
    static let slack = TextSpot(pid: 1, name: "Slack", field: box(101))
    static let slackSearch = TextSpot(pid: 1, name: "Slack", field: box(102))
    static let notes = TextSpot(pid: 2, name: "Notes", field: box(201))

    var front: pid_t = 1
    var cursor: [pid_t: AXUIElement] = [:]
    var names: [pid_t: String] = [1: "Slack", 2: "Notes"]
    /// Putting the cursor back works (false: the box is gone).
    var focusWorks = true
    var log: [String] = []

    var here: TextSpot { TextSpot(pid: front, name: names[front] ?? "?", field: cursor[front]) }

    func moveTo(_ spot: TextSpot) {
        front = spot.pid
        cursor[spot.pid] = spot.field
    }

    func name(_ field: AXUIElement) -> String {
        let named = [(FakeDesk.slack.field!, "Slack"), (FakeDesk.slackSearch.field!, "Slack search"), (FakeDesk.notes.field!, "Notes")]
        return named.first { CFEqual($0.0, field) }?.1 ?? "?"
    }

    /// Wires `goBack` to this desk, and (`keys`) its paste and Return to the log.
    func attach(_ goBack: GoBack, keys: Bool = true) {
        goBack.current = { [unowned self] in here }
        goBack.bringForward = { [unowned self] pid in front = pid; log.append("front:\(names[pid]!)"); return true }
        goBack.focus = { [unowned self] spot in
            guard focusWorks, let field = spot.field else { return }
            cursor[spot.pid] = field
            log.append("cursor:\(name(field))")
        }
        goBack.hasFocus = { [unowned self] spot in front == spot.pid && spot.isSame(as: here) && cursor[spot.pid] != nil }
        goBack.blockInput = { [unowned self] on in log.append(on ? "block" : "unblock") }
        goBack.sendDelay = 0
        goBack.leaveDelay = 0
        goBack.holdInput = 0
        goBack.focusTimeout = 0.1
        guard keys else { return }
        let injector = goBack.injector
        injector.canPaste = { true }
        injector.charBeforeCursor = { nil }
        injector.restoreDelay = 0.01
        injector.paste = { [unowned self] in log.append("paste:\(injector.pasteboard.string(forType: .string) ?? "")@\(names[front]!)") }
        injector.postReturn = { [unowned self] in log.append("return@\(names[front]!)") }
    }
}

final class GoBackTests: XCTestCase {
    private var desk: FakeDesk!
    private var goBack: GoBack!

    override func setUp() {
        desk = FakeDesk()
        let injector = TextInjector()
        injector.pasteboard = makePasteboard(self)
        goBack = GoBack(injector: injector)
        desk.attach(goBack)
    }

    private func deliver(_ text: String, to target: TextSpot, send: Bool) -> GoBack.Outcome {
        var outcome: GoBack.Outcome?
        Task { @MainActor in outcome = await goBack.deliver(text, to: target, send: { send }) }
        waitUntil { outcome != nil }
        return outcome ?? .lost("timed out")
    }

    func testStillInTheSameBoxPastesAsUsual() {
        desk.moveTo(FakeDesk.slack)
        XCTAssertTrue(goBack.isStill(at: FakeDesk.slack))
        desk.moveTo(FakeDesk.slackSearch)
        XCTAssertFalse(goBack.isStill(at: FakeDesk.slack), "another box in the same app")
        desk.moveTo(FakeDesk.notes)
        XCTAssertFalse(goBack.isStill(at: FakeDesk.slack))
    }

    /// An app that doesn't say where its cursor is: being in it is as close as it gets.
    func testAnAppThatDoesNotSayCountsByApp() {
        desk.front = 1
        XCTAssertTrue(goBack.isStill(at: FakeDesk.slack))
        XCTAssertTrue(TextSpot(pid: 1, name: "Slack", field: nil).isSame(as: FakeDesk.slack))
    }

    func testGoesBackSendsAndBringsYouBack() {
        desk.moveTo(FakeDesk.slack)
        desk.moveTo(FakeDesk.notes)
        XCTAssertEqual(deliver("hi", to: FakeDesk.slack, send: true), .delivered)
        XCTAssertEqual(desk.log, ["block", "front:Slack", "cursor:Slack", "paste:hi@Slack", "return@Slack",
                                  "front:Notes", "cursor:Notes", "unblock"])
    }

    func testWithoutEnterItPastesOnly() {
        desk.moveTo(FakeDesk.slack)
        desk.moveTo(FakeDesk.notes)
        XCTAssertEqual(deliver("hi", to: FakeDesk.slack, send: false), .delivered)
        XCTAssertFalse(desk.log.contains { $0.hasPrefix("return") })
        XCTAssertEqual(desk.front, 2, "back where you were")
    }

    /// Moved to the search box in the same app: back to the message box, then back to search.
    func testAnotherBoxInTheSameApp() {
        desk.moveTo(FakeDesk.slackSearch)
        XCTAssertEqual(deliver("hi", to: FakeDesk.slack, send: true), .delivered)
        XCTAssertEqual(desk.log, ["block", "front:Slack", "cursor:Slack", "paste:hi@Slack", "return@Slack",
                                  "front:Slack", "cursor:Slack search", "unblock"])
    }

    /// The box is gone: nothing is pasted or sent anywhere; the text waits on the clipboard.
    func testCantGetBackLeavesItOnTheClipboard() {
        desk.moveTo(FakeDesk.slack)
        desk.moveTo(FakeDesk.notes)
        desk.cursor[1] = FakeDesk.box(999)  // Slack's cursor is somewhere else now
        desk.focusWorks = false
        XCTAssertEqual(deliver("hi", to: FakeDesk.slack, send: true), .lost("Slack"))
        XCTAssertFalse(desk.log.contains { $0.hasPrefix("paste") || $0.hasPrefix("return") }, "\(desk.log)")
        XCTAssertEqual(desk.front, 2, "back where you were")
        XCTAssertEqual(desk.log.last, "unblock")
        XCTAssertEqual(goBack.injector.pasteboard.string(forType: .string), "hi")
    }

    /// Dictated into an app that doesn't say where its cursor is, then left it: there's no box to go
    /// back to, so nothing moves.
    func testNoBoxToGoBackTo() {
        desk.front = 2
        XCTAssertEqual(deliver("hi", to: TextSpot(pid: 1, name: "Slack", field: nil), send: true), .lost("Slack"))
        XCTAssertEqual(desk.log, [])
        XCTAssertEqual(goBack.injector.pasteboard.string(forType: .string), "hi")
    }

    /// Keys and clicks stay blocked until a second (here 0.2 s) after the paste.
    func testInputStaysBlockedAfterThePaste() {
        goBack.holdInput = 0.2
        var pastedAt: TimeInterval = 0, unblockedAt: TimeInterval = 0
        let paste = goBack.injector.paste
        goBack.injector.paste = { paste(); pastedAt = ProcessInfo.processInfo.systemUptime }
        let block = goBack.blockInput
        goBack.blockInput = { on in block(on); if !on { unblockedAt = ProcessInfo.processInfo.systemUptime } }
        desk.moveTo(FakeDesk.slack)
        desk.moveTo(FakeDesk.notes)
        XCTAssertEqual(deliver("hi", to: FakeDesk.slack, send: false), .delivered)
        XCTAssertGreaterThanOrEqual(unblockedAt - pastedAt, 0.19)
    }

    func testTheBlockerLetsThisAppsKeysAndTheMouseButtonsThrough() {
        XCTAssertTrue(InputBlocker.blocks(.keyDown, marker: 0))
        XCTAssertTrue(InputBlocker.blocks(.leftMouseDown, marker: 0))
        XCTAssertTrue(InputBlocker.blocks(.rightMouseDown, marker: 0))
        XCTAssertFalse(InputBlocker.blocks(.keyDown, marker: TextInjector.syntheticMarker), "this app's ⌘V and Return")
        XCTAssertFalse(InputBlocker.blocks(.otherMouseDown, marker: 0), "the dictation and Enter buttons")
        XCTAssertFalse(InputBlocker.blocks(.keyUp, marker: 0), "a held key still gets its release")
        XCTAssertFalse(InputBlocker.blocks(.leftMouseUp, marker: 0))
    }
}
