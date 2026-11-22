import AppKit
import XCTest
@testable import DictationKit

/// Keystroke mode: the pasted text followed in memory from your keys.
final class TypedEditTests: XCTestCase {
    /// Applies `keys` to a paste of `pasted`; nil if it gave up.
    private func typed(_ pasted: String, _ keys: [EditKey]) -> String? {
        var edit = TypedEdit(pasted: pasted)
        for key in keys { guard edit.apply(key) else { return nil } }
        return edit.span
    }

    private func type(_ text: String) -> [EditKey] { text.map { .text(String($0)) } }
    private func times(_ n: Int, _ key: EditKey) -> [EditKey] { Array(repeating: key, count: n) }

    func testBackspaceAndRetypeTheLastWord() {
        XCTAssertEqual(typed(" I use cloud", times(5, .backspace) + type("Claude")), " I use Claude")
    }

    func testArrowsMoveTheCursorAndDeleteRemovesAhead() {
        XCTAssertEqual(typed(" a cloud b", times(2, .left) + times(5, .left) + times(5, .forwardDelete) + type("Claude")), " a Claude b")
        XCTAssertEqual(typed(" ab", [.left, .right, .text("c")]), " abc")
    }

    func testWordMovesAndOptionBackspace() {
        XCTAssertEqual(typed(" I use cloud code", [.wordLeft, .wordLeft, .deleteWordBack] + type("love ")), " I love cloud code",
                       "⌥⌫ takes the word and the space after it, as on a Mac")
        XCTAssertEqual(typed(" one two three", [.wordLeft, .wordLeft, .wordRight, .text("s")]), " one twos three")
    }

    func testShiftSelectionsAreReplaced() {
        XCTAssertEqual(typed(" cloud code", times(4, EditKey.left.shifted) + type("Code")), " cloud Code")
        XCTAssertEqual(typed(" I use cloud", [EditKey.wordLeft.shifted] + type("Claude")), " I use Claude")
        XCTAssertEqual(typed(" a cloud", [EditKey.wordLeft.shifted, .backspace] + type("b")), " a b")
        XCTAssertEqual(typed(" a cloud", [EditKey.wordLeft.shifted, .left, .text("x")]), " a xcloud", "← lands at the selection's start")
        XCTAssertEqual(typed(" a cloud", [.wordLeft, EditKey.right.shifted, EditKey.right.shifted, .right, .text("x")]), " a clxoud",
                       "→ lands at its end")
    }

    /// What's typed after the paste, starting with a space, isn't part of the edit; typed right onto
    /// its last word, it is.
    func testTextTypedAfterThePasteIsNotPartOfIt() {
        XCTAssertEqual(typed(" fix cloud", times(5, .backspace) + type("Claude and more")), " fix Claude",
                       "the last word retyped, then more")
        XCTAssertEqual(typed(" fix cloud", type(" and more")), " fix cloud")
        XCTAssertEqual(typed(" fix cloud", type("s and more")), " fix clouds")
        XCTAssertEqual(typed(" a cloud", type(" thanks") + times(7, .left) + times(5, .backspace) + type("Claude")), " a Claude",
                       "a fix made after typing on: the typed text stays apart")
    }

    func testEditsInChineseByCharacter() {
        XCTAssertEqual(typed("我用克劳的", [.backspace, .text("德")]), "我用克劳德")
    }

    /// Wherever it can't be sure what the box holds now, it gives up.
    func testGivesUpWhereItCantFollow() {
        XCTAssertNil(typed(" a", [.other]), "any other shortcut")
        XCTAssertNil(typed(" a", [.returnKey]), "Return ends the watch; it isn't an edit")
        XCTAssertNil(typed("ab", times(3, .backspace)), "into text before the paste")
        XCTAssertNil(typed("ab", times(3, .left)))
        XCTAssertNil(typed("ab", [.right]), "into text after it")
        XCTAssertNil(typed("ab", [.forwardDelete]))
        XCTAssertNil(typed("one two", [.wordLeft, .wordLeft]), "a word that may go on before the paste")
        XCTAssertNil(typed(" one two", [.wordLeft, .wordRight]), "to the end of what's known")
        XCTAssertNil(typed(" 我用克劳的", [.wordLeft]), "Chinese words are split by a dictionary")
        XCTAssertNil(typed("one", [.deleteWordBack]))
    }

    /// Keys from the event tap: what's followed, and every shortcut.
    func testKeysFromTheEventTap() {
        let none: CGEventFlags = []
        XCTAssertEqual(EditKey(code: 0, flags: none, characters: "a"), .text("a"))
        XCTAssertEqual(EditKey(code: 0, flags: .maskShift, characters: "A"), .text("A"))
        XCTAssertEqual(EditKey(code: 0, flags: .maskAlternate, characters: "å"), .text("å"))
        XCTAssertEqual(EditKey(code: 14, flags: .maskAlternate, characters: ""), .other, "a dead key (⌥E)")
        XCTAssertEqual(EditKey(code: 0, flags: .maskCommand, characters: "a"), .other, "⌘A")
        XCTAssertEqual(EditKey(code: 6, flags: .maskControl, characters: "\u{1A}"), .other, "⌃Z")
        XCTAssertEqual(EditKey(code: 0x33, flags: none, characters: "\u{7F}"), .backspace)
        XCTAssertEqual(EditKey(code: 0x33, flags: .maskAlternate, characters: "\u{7F}"), .deleteWordBack)
        XCTAssertEqual(EditKey(code: 0x33, flags: .maskCommand, characters: "\u{7F}"), .other, "⌘⌫")
        XCTAssertEqual(EditKey(code: 0x75, flags: none, characters: "\u{F728}"), .forwardDelete)
        let arrow: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]  // every arrow press has these
        XCTAssertEqual(EditKey(code: 0x7B, flags: arrow, characters: "\u{F702}"), .left)
        XCTAssertEqual(EditKey(code: 0x7C, flags: arrow.union(.maskShift), characters: "\u{F703}"), EditKey.right.shifted)
        XCTAssertEqual(EditKey(code: 0x7B, flags: arrow.union([.maskAlternate, .maskShift]), characters: "\u{F702}"), EditKey.wordLeft.shifted)
        XCTAssertEqual(EditKey(code: 0x7B, flags: arrow.union(.maskCommand), characters: "\u{F702}"), .other, "⌘←")
        XCTAssertEqual(EditKey(code: 0x7E, flags: arrow, characters: "\u{F700}"), .other, "↑")
        XCTAssertEqual(EditKey(code: 0x30, flags: none, characters: "\t"), .other, "Tab")
        XCTAssertEqual(EditKey(code: 0x35, flags: none, characters: "\u{1B}"), .other, "Esc")
        XCTAssertEqual(EditKey(code: 0x24, flags: none, characters: "\r"), .returnKey)
        XCTAssertEqual(EditKey(code: 0x24, flags: .maskShift, characters: "\r"), .returnKey, "⇧↩ ends it too")
        XCTAssertEqual(EditKey(code: 0x4C, flags: none, characters: "\u{3}"), .returnKey)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x7B, keyDown: true)!  // made, never posted
        event.flags = [.maskAlternate, .maskSecondaryFn]
        XCTAssertEqual(EditKey(event: event), .wordLeft)
    }
}

/// Readback mode: where the pasted text is in the box, read after read.
final class SpanTrackerTests: XCTestCase {
    private func tracker(_ value: String, pasted: String) -> SpanTracker? {
        SpanTracker(value: value, cursor: value.utf16.count, pasted: pasted)
    }

    func testTheProbeFindsThePasteWhereTheCursorIs() {
        XCTAssertEqual(SpanTracker(value: "Hi there, I use cloud", cursor: 21, pasted: " I use cloud")?.span, " I use cloud")
        XCTAssertEqual(SpanTracker(value: "Hi I use cloud. Bye", cursor: 15, pasted: " I use cloud.")?.span, " I use cloud.")
        XCTAssertNil(SpanTracker(value: "Hi there", cursor: 8, pasted: " I use cloud"), "the paste isn't there (not taken yet, or changed)")
        XCTAssertNil(SpanTracker(value: "Hi I use cloud", cursor: 3, pasted: " I use cloud"), "not where the cursor says")
        XCTAssertNil(SpanTracker(value: "Hi I use cloud", cursor: nil, pasted: " I use cloud"), "the app doesn't say where the cursor is")
        XCTAssertNil(SpanTracker(value: "😀 cloud", cursor: 99, pasted: " cloud"))
    }

    func testAnEditInsideIsTheSpans() {
        var t = tracker("Hi I use cloud code.", pasted: " I use cloud code.")!
        XCTAssertTrue(t.update("Hi I use Claude code."))
        XCTAssertTrue(t.update("Hi I use Claude Code."))
        XCTAssertEqual(t.span, " I use Claude Code.")
    }

    func testEditsBeforeAndAfterMoveItButArentPartOfIt() {
        var t = SpanTracker(value: "Hi cloud. Bye", cursor: 9, pasted: " cloud.")!
        XCTAssertTrue(t.update("Hello cloud. Bye"), "before")
        XCTAssertTrue(t.update("Hello cloud. Bye now"), "after")
        XCTAssertTrue(t.update("Hello Claude. Bye now"))
        XCTAssertEqual(t.span, " Claude.")
    }

    func testTextTypedAtTheEndStartingWithASpaceIsntPartOfIt() {
        var t = tracker("Hi cloud", pasted: " cloud")!
        XCTAssertTrue(t.update("Hi Claude"))
        XCTAssertTrue(t.update("Hi Claude and more"))
        XCTAssertEqual(t.span, " Claude")
        XCTAssertTrue(t.update("Hi Claudes and more"), "typed onto its last word")
        XCTAssertEqual(t.span, " Claudes")
    }

    func testAChangeAcrossItsEdgeKeepsTheLastState() {
        var t = tracker("Hi cloud", pasted: " cloud")!
        XCTAssertTrue(t.update("Hi Claude"))
        XCTAssertFalse(t.update(""), "the box was cleared (sent)")
        XCTAssertEqual(t.span, " Claude")
        var u = tracker("Hi cloud", pasted: " cloud")!
        XCTAssertFalse(u.update("Hello"), "a selection from before it into it")
        XCTAssertEqual(u.span, " cloud")
    }

    /// The paste was the whole box: sent, then a new message typed, is not an edit of it.
    func testAllOfItReplacedCantBeFollowed() {
        var t = tracker("I use cloud", pasted: "I use cloud")!
        XCTAssertFalse(t.update(""), "the box cleared")
        XCTAssertEqual(t.span, "I use cloud")
        XCTAssertTrue(t.update("ok sounds good"), "the box's text changes…")
        XCTAssertFalse(t.sharesAWordWithThePaste, "…but none of the paste is left: only keys can say it's an edit")
        var u = tracker("Hi I use cloud", pasted: " I use cloud")!
        XCTAssertTrue(u.update("Hi I use Claude"))
        XCTAssertTrue(u.sharesAWordWithThePaste)
    }

    /// Typed onto its last word, only up to the first space or sentence mark is the span's.
    func testTextTypedOntoTheEndStopsAtASpaceOrSentenceMark() {
        var t = tracker("I use cloud", pasted: "I use cloud")!
        XCTAssertTrue(t.update("I use clouds, and my address is 1 Main St"))
        XCTAssertEqual(t.span, "I use clouds")
        var u = tracker("我用克劳的", pasted: "我用克劳的")!
        XCTAssertTrue(u.update("我用克劳的。好的"))
        XCTAssertEqual(u.span, "我用克劳的")
    }

    /// A paste with nothing put in front: text typed at its start is its first word. With a space put
    /// in front, it's the text before it.
    func testTextTypedAtTheStart() {
        var t = tracker("This is great", pasted: "This is great")!
        XCTAssertTrue(t.update(" is great"))
        XCTAssertTrue(t.update("That is great"))
        XCTAssertEqual(t.span, "That is great")
        var u = tracker("Hi is great", pasted: " is great")!
        XCTAssertTrue(u.update("Hi there is great"))
        XCTAssertEqual(u.span, " is great")
        var v = tracker("Hi there", pasted: "there")!
        XCTAssertTrue(v.update("Hi so there"), "typed before it, ending in a space")
        XCTAssertEqual(v.span, "there")
    }

    func testOffsetsAreUTF16() {
        var t = tracker("😀 我用克劳的", pasted: " 我用克劳的")!
        XCTAssertTrue(t.update("😀😀 我用克劳的"))
        XCTAssertTrue(t.update("😀😀 我用克劳德"))
        XCTAssertEqual(t.span, " 我用克劳德")
    }
}

/// Timers on a clock the test moves.
final class FakeClock {
    private(set) var time: TimeInterval = 0
    private var timers: [(at: TimeInterval, n: Int, fire: () -> Void)] = []
    private var made = 0

    func after(_ delay: TimeInterval, _ fire: @escaping () -> Void) {
        made += 1
        timers.append((time + delay, made, fire))
    }

    /// Moves on, firing each timer due on the way, in order.
    func advance(_ seconds: TimeInterval) {
        let end = time + seconds
        while let next = timers.filter({ $0.at <= end + 1e-9 }).min(by: { ($0.at, $0.n) < ($1.at, $1.n) }) {
            timers.removeAll { $0.n == next.n }
            time = max(time, next.at)
            next.fire()
        }
        time = end
    }
}

/// The Mac as the edit watcher sees it, faked: the text box it reads, secure input, the input
/// source, the keys, clicks and app switches it's sent. Reads and saves run inline.
final class FakeEditDesk {
    let clock = FakeClock()
    /// What the box holds now.
    var box: EditWatcher.Read?
    /// The app says what's in its box (false: it doesn't, so keystroke mode).
    var answers = true
    var focused = true
    private(set) var reads = 0
    var secureField = false
    var secureInput = false
    var inputMethod = false
    var bundleIDs: [pid_t: String] = [1: "com.tinyspeck.slackmacgap", 2: "com.apple.Notes"]
    private(set) var keys: ((EditKey) -> Void)?
    private(set) var clicks: (() -> Void)?
    private(set) var apps: ((pid_t) -> Void)?

    func attach(_ watcher: EditWatcher) {
        watcher.read = { [unowned self] _ in reads += 1; return answers ? box : nil }
        watcher.isSecureField = { [unowned self] _ in secureField }
        watcher.secureInput = { [unowned self] in secureInput }
        watcher.inputMethodActive = { [unowned self] in inputMethod }
        watcher.bundleID = { [unowned self] in bundleIDs[$0] }
        watcher.listen = { [unowned self] in keys = $0 }
        watcher.watchClicks = { [unowned self] in clicks = $0 }
        watcher.watchApps = { [unowned self] in apps = $0 }
        watcher.now = { [unowned self] in clock.time }
        watcher.after = { [unowned self] delay, fire in clock.after(delay, fire) }
        watcher.background = { $0() }
        watcher.toMain = { $0() }
    }

    /// Sets the box's text, the cursor at its end (or `cursor`).
    func show(_ value: String, cursor: Int? = nil, focused: Bool? = nil) {
        box = EditWatcher.Read(value: value, cursor: cursor ?? value.utf16.count, focused: focused ?? self.focused)
    }

    func press(_ keys: [EditKey]) { for key in keys { self.keys?(key) } }
    func type(_ text: String) { press(text.map { .text(String($0)) }) }
}

/// The edit watcher with a fake Mac: when it watches, how it follows an edit, when it ends, and what
/// it keeps.
final class EditWatcherTests: XCTestCase {
    private var services: AppServices!
    private var desk: FakeEditDesk!
    private var watcher: EditWatcher { services.editWatcher }
    private var history: HistoryStore { services.history }
    private var captures = 0

    override func setUp() {
        services = makeServices(self)
        services.settings.learnFromEdits = true
        desk = FakeEditDesk()
        desk.attach(services.editWatcher)
        services.editWatcher.onCapture = { [unowned self] in captures += 1 }
    }

    /// A dictation of `text` pasted (with a space in front) after `before` in Slack's box, followed by
    /// `after`; the probe left to run unless `probe` is false. Its History id.
    @discardableResult
    private func paste(_ text: String, after before: String = "Hi", then rest: String = "", probe: Bool = true) -> UUID {
        let id = history.add(text: text, duration: 1)!
        let pasted = " " + text
        desk.show(before + pasted + rest, cursor: (before + pasted).utf16.count)
        watcher.arm(spot: FakeDesk.slack, pasted: pasted, text: text, entry: id)
        if probe { desk.clock.advance(EditWatcher.probeDelay) }
        return id
    }

    private var capture: Capture? { history.entries.first?.capture }
    private var stats: EditWatchStats.App? { watcher.stats.apps["Slack"] }

    // MARK: Readback

    func testReadbackFollowsTheBoxAndKeepsTheEditOnReturn() {
        paste("I use cloud code.")
        XCTAssertEqual(desk.reads, 1, "the probe")
        desk.press([.wordLeft, .wordLeft]); desk.type("Claude"); desk.show("Hi I use Claude cloud code.")
        desk.clock.advance(EditWatcher.pause)
        XCTAssertEqual(desk.reads, 2, "read once typing paused")
        desk.press(Array(repeating: .forwardDelete, count: 6)); desk.show("Hi I use Claude code.")
        desk.press([.returnKey])
        XCTAssertEqual(desk.reads, 3, "and once more before the Return went on")
        XCTAssertEqual(capture, Capture(edited: "I use Claude code.", mode: .readback, app: "Slack", state: .waiting))
        XCTAssertEqual(history.waiting.count, 1)
        XCTAssertEqual(captures, 1)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(stats, EditWatchStats.App(armed: 1, probesFailed: 0, gaveUp: 0))
    }

    func testAPauseReadWaitsForTypingToStop() {
        paste("cloud")
        for _ in 0..<5 { desk.type("x"); desk.clock.advance(0.3) }
        XCTAssertEqual(desk.reads, 1, "still typing")
        desk.clock.advance(EditWatcher.pause)
        XCTAssertEqual(desk.reads, 2)
    }

    func testNoKeysSinceTheLastReadNoReadBeforeReturn() {
        paste("cloud")
        desk.type("s"); desk.show("Hi clouds")
        desk.clock.advance(EditWatcher.pause)
        desk.press([.returnKey])
        XCTAssertEqual(desk.reads, 2)
        XCTAssertEqual(capture?.edited, "clouds")
    }

    /// The read before a Return holds that key back 50 ms at most; then the last read stands.
    func testTheReadBeforeReturnIsCappedAt50ms() {
        paste("I use cloud.")
        desk.show("Hi I use Claude.")
        desk.press([.text("x")])
        desk.clock.advance(EditWatcher.pause)  // read: "I use Claude."
        desk.press([.text("y")])
        desk.show("Hi I use Claude Code.")
        let slow = desk.box
        watcher.read = { _ in Thread.sleep(forTimeInterval: 0.3); return slow }
        watcher.background = { work in DispatchQueue.global().async(execute: work) }
        let started = Date()
        desk.press([.returnKey])
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.15, "the Return wasn't held for the slow read")
        XCTAssertEqual(capture?.edited, "I use Claude.", "the last read in time")
    }

    // MARK: Keystroke mode

    func testWithoutReadbackKeysAreFollowedInMemory() {
        desk.answers = false
        paste("I use cloud")
        desk.press(Array(repeating: .backspace, count: 5)); desk.type("Claude"); desk.press([.returnKey])
        XCTAssertEqual(capture, Capture(edited: "I use Claude", mode: .keystrokes, app: "Slack", state: .waiting))
        XCTAssertEqual(stats, EditWatchStats.App(armed: 1, probesFailed: 1, gaveUp: 0))
        XCTAssertEqual(desk.reads, 1, "keystroke mode reads nothing more")
    }

    /// Keys typed before the probe has an answer aren't lost when it fails.
    func testKeysBeforeTheProbeAreKept() {
        paste("I use cloud", probe: false)
        desk.press(Array(repeating: .backspace, count: 5)); desk.type("Claude")
        desk.show("Hi I use Claude")  // the paste isn't where it was any more
        desk.clock.advance(EditWatcher.probeDelay)
        desk.press([.returnKey])
        XCTAssertEqual(capture?.edited, "I use Claude")
        XCTAssertEqual(capture?.mode, .keystrokes)
    }

    /// Ended before the probe had an answer (it hadn't checked for a password field): nothing kept.
    func testEndedBeforeTheProbeKeepsNothing() {
        paste("I use cloud", probe: false)
        desk.press(Array(repeating: .backspace, count: 5)); desk.type("Claude"); desk.press([.returnKey])
        XCTAssertFalse(watcher.isWatching)
        XCTAssertNil(capture)
    }

    /// A click in readback mode (it may have sent the text) reads the box at once.
    func testAClickReadsTheBox() {
        paste("I use cloud")
        desk.type("x"); desk.show("Hi I use Claude")
        desk.clicks?()
        XCTAssertEqual(desk.reads, 2)
        desk.show("Hi ")  // sent: the box emptied
        desk.type("o"); desk.show("Hi ok sounds good")
        desk.press([.returnKey])
        XCTAssertEqual(capture?.edited, "I use Claude", "what was there before the click sent it")
    }

    /// Dictated into an empty box, sent with a click, then the next message typed by hand: that
    /// message is not an edit of the dictation.
    func testANewMessageAfterASendIsNotAnEdit() {
        let id = history.add(text: "I use cloud", duration: 1)!
        desk.show("I use cloud")
        watcher.arm(spot: FakeDesk.slack, pasted: "I use cloud", text: "I use cloud", entry: id)
        desk.clock.advance(EditWatcher.probeDelay)
        desk.type("ok sounds good"); desk.show("ok sounds good")
        desk.press([.returnKey])
        XCTAssertNil(capture)
    }

    func testTheProbeFailsWhenThePasteIsntWhereTheCursorIs() {
        paste("I use cloud", probe: false)
        desk.show("Hi I use cloud", cursor: 2)
        desk.clock.advance(EditWatcher.probeDelay)
        XCTAssertEqual(stats?.probesFailed, 1)
        desk.focused = false
        paste("again")  // the box isn't focused: no readback either
        XCTAssertEqual(stats?.probesFailed, 2)
    }

    func testKeystrokeModeGivesUpOnAClickAShortcutOrAnInputMethod() {
        for giveUp in [{ self.desk.clicks?() }, { self.desk.press([.other]) }, { self.desk.inputMethod = true; self.desk.type("a") },
                       { self.desk.press([.right]) }] {
            desk.inputMethod = false
            desk.answers = false
            paste("I use cloud")
            desk.press([.backspace]); desk.type("d")
            giveUp()
            XCTAssertFalse(watcher.isWatching)
            desk.press([.returnKey])
            XCTAssertNil(capture, "nothing kept")
        }
        XCTAssertEqual(stats?.gaveUp, 4)
        XCTAssertNil(desk.clicks, "the click monitor is gone with the watch")
    }

    func testAnInputMethodOnFromTheStartMeansNoKeystrokeMode() {
        desk.inputMethod = true
        desk.answers = false
        paste("我用克劳的")
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(stats?.gaveUp, 1)
    }

    // MARK: Never armed

    func testNeverArmed() {
        services.settings.learnFromEdits = false
        paste("one")
        XCTAssertFalse(watcher.isWatching, "Learn from my edits off")
        services.settings.learnFromEdits = true

        services.settings.exclude(ExcludedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"))
        paste("two")
        XCTAssertFalse(watcher.isWatching, "an excluded app")
        services.settings.include(ExcludedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"))

        desk.secureInput = true
        paste("three")
        XCTAssertFalse(watcher.isWatching, "secure input on")
        desk.secureInput = false

        desk.secureField = true
        paste("four")
        XCTAssertFalse(watcher.isWatching, "a password field")
        XCTAssertNil(desk.keys)
        XCTAssertNil(stats, "none of them counts as armed")
    }

    // MARK: Ends on

    func testEndsOnAFocusChangeWithWhatItHad() {
        paste("I use cloud")
        desk.type("x")
        desk.show("Hi I use Claude", focused: false)
        desk.clock.advance(EditWatcher.pause)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(capture?.edited, "I use Claude")
    }

    func testEndsOnAnAppChangeAfterOneLastRead() {
        paste("I use cloud")
        desk.type("x")
        desk.show("Hi I use Claude")
        desk.apps?(1)
        XCTAssertTrue(watcher.isWatching, "the same app coming forward again")
        desk.apps?(2)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(capture?.edited, "I use Claude")
        XCTAssertNil(desk.apps)
    }

    func testANewDictationEndsItWithoutARead() {
        paste("I use cloud")
        desk.type("x")
        desk.show("Hi I use Claude")
        desk.clock.advance(EditWatcher.pause)
        let reads = desk.reads
        desk.type("y")
        desk.show("Hi I use Claude Code")
        watcher.endNow()
        XCTAssertEqual(desk.reads, reads, "start() waits on nothing")
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(capture?.edited, "I use Claude", "what it had")
    }

    func testEndsAfter30sWithoutAKey() {
        paste("I use cloud")
        desk.clock.advance(20)
        desk.type("x"); desk.show("Hi I use Claude")
        desk.clock.advance(29)
        XCTAssertTrue(watcher.isWatching, "30 s from the last key, not from the paste")
        desk.clock.advance(2)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(capture?.edited, "I use Claude")
    }

    func testEndsAfterTwoMinutesWhateverYouType() {
        paste("I use cloud")
        for _ in 0..<130 { desk.type("x"); desk.clock.advance(1) }
        XCTAssertFalse(watcher.isWatching)
    }

    func testSecureInputTurningOnDropsIt() {
        paste("I use cloud")
        desk.type("x"); desk.show("Hi I use Claude")
        desk.secureInput = true
        desk.clock.advance(EditWatcher.pause)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertNil(capture)
        desk.secureInput = false

        desk.answers = false
        paste("I use cloud")
        desk.press(Array(repeating: .backspace, count: 5)); desk.type("Claude")
        desk.secureInput = true
        desk.press([.returnKey])
        XCTAssertNil(history.entries.first?.capture, "keystroke mode too")
    }

    func testAChangeItCantFollowEndsItOnTheLastRead() {
        paste("I use cloud")
        desk.type("x"); desk.show("Hi I use Claude")
        desk.clock.advance(EditWatcher.pause)
        desk.type("y"); desk.show("")  // sent with a click: the box is empty
        desk.clock.advance(EditWatcher.pause)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(capture?.edited, "I use Claude")
    }

    // MARK: What's kept

    func testAnEditThatChangesNoWordLeavesNothing() {
        for (edit, why) in [("Hi I use cloud. And more", "text added after it"), ("Hi ", "all of it deleted"),
                            ("Hi I use cloud.", "nothing changed"), ("Hi I use cloud", "punctuation only")] {
            paste("I use cloud.")
            desk.type("x"); desk.show(edit)
            desk.press([.returnKey])
            XCTAssertNil(capture, why)
        }
        XCTAssertEqual(captures, 0)
    }

    /// Only the pasted text as you left it is saved: not the rest of the box, not what you typed after it.
    func testNothingButTheEditIsWrittenToDisk() throws {
        paste("I use cloud.", after: "SECRET-BEFORE", then: " SECRET-AFTER")
        // Fixed and typed on in one go, no pause: one read holds both, and the keys say where the paste ended.
        desk.press([.wordLeft, EditKey.wordRight.shifted]); desk.type("Claude"); desk.press([.right]); desk.type(" SECRET-TYPED")
        desk.show("SECRET-BEFORE I use Claude. SECRET-TYPED SECRET-AFTER")
        desk.press([.returnKey])
        desk.answers = false
        paste("call cloud", after: "SECRET-BEFORE")
        desk.press(Array(repeating: .backspace, count: 5)); desk.type("Claude SECRET-KEYS"); desk.press([.returnKey])
        XCTAssertEqual(history.entries.compactMap(\.capture?.edited), ["call Claude", "I use Claude."])
        for url in [history.fileURL, watcher.stats.fileURL] {
            let saved = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(saved.contains("SECRET"), url.lastPathComponent)
        }
    }

    func testCountsArePerAppAndSaved() {
        paste("one")
        desk.press([.returnKey])
        desk.answers = false
        paste("two")
        let reloaded = EditWatchStats(fileURL: watcher.stats.fileURL)
        XCTAssertEqual(reloaded.apps, ["Slack": EditWatchStats.App(armed: 2, probesFailed: 1, gaveUp: 0)])
    }

    /// The tap hands the watcher your keys only: not this app's own ⌘V (which reaches the tap after
    /// the watch it starts), and nothing at all while there's no watch.
    func testTheTapPassesOnlyYourKeys() {
        let hotkeys = HotkeyManager(hotkey: .fn, mode: .hold, mouseButton: .off)
        var seen: [EditKey] = []
        hotkeys.onKey = { seen.append(EditKey(event: $0)) }
        let ours = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)!  // ⌘V, made and never posted
        ours.flags = .maskCommand
        ours.setIntegerValueField(.eventSourceUserData, value: TextInjector.syntheticMarker)
        let yours = CGEvent(keyboardEventSource: nil, virtualKey: 0x33, keyDown: true)!  // Backspace
        XCTAssertNotNil(hotkeys.handleTap(type: .keyDown, event: ours))
        XCTAssertNotNil(hotkeys.handleTap(type: .keyDown, event: yours), "passed on to the app")
        XCTAssertEqual(seen, [.backspace])
    }
}
